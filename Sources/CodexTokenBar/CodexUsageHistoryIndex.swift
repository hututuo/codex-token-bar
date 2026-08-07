import CryptoKit
import Darwin
import Foundation
import SQLite3

struct CodexUsageHistoryIndexError: LocalizedError {
    let operation: String
    let underlying: Error

    var errorDescription: String? {
        "精确历史索引\(operation)失败：\(underlying.localizedDescription)"
    }
}

struct CodexUsageSourceChangedError: LocalizedError {
    let path: String

    var errorDescription: String? {
        "会话文件在精确索引期间发生变化，将保留上一份完整结果并重试：\(path)"
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

        static func full(endOffset: UInt64) -> IndexedSessionParseRequest {
            IndexedSessionParseRequest(
                hashingStartOffset: 0,
                parsingStartOffset: 0,
                endOffset: endOffset,
                validationBoundary: nil,
                initialState: .empty
            )
        }
    }
}

final class CodexUsageHistoryIndex: @unchecked Sendable {
    struct StoredEvent {
        let stableID: String
        let event: TokenEvent
        let sourceID: Int64
        let sourceOffset: UInt64
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
        let signature: SourceSignature
        let checkpoint: SourceCheckpoint?
    }

    private struct SourceIdentity {
        let id: Int64
        let path: String
    }

    private struct SourceCheckpoint {
        let resumeOffset: UInt64
        let parserState: CodexUsageAnalyzer.IndexedSessionParserState
        let auditChunkIndex: UInt64
    }

    private struct FullRebuildJob {
        let file: URL
        let sessionID: String
        let observedSignature: SourceSignature
    }

    private struct StagedFullRebuild {
        let job: FullRebuildJob
        let databaseURL: URL
        let committedSignature: SourceSignature
        let eventCount: Int
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

    private static let schemaVersion = "5"
    private static let inPlaceSchemaVersions: Set<String> = ["2", "3", "4", "5"]
    private static let forkReplayBoundaryRevision = "explicit-subagent-delayed-context-v3"
    /// Bump whenever event parsing or source-bucket identity semantics change.
    /// Existing attribution ledgers then fail closed instead of reconciling
    /// contributions produced by incompatible parsers.
    private static let attributionProvenanceRevision = "source-bucket-v4-fork-replay-boundary-v2"
    private static let sessionCatalogSchemaVersion = "1"
    private static let chunkSize: UInt64 = 4 * 1_024 * 1_024
    private static let explicitSubagentFirstLineLimit = 256 * 1_024
    private static let cacheDirectoryName = "CodexTokenBarSwift"
    private static let indexNamespace = "exact-usage-history-v1"
    private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"
    private static let disabledCacheEnvironmentKey = "CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE"
    private static let operationLocks = CodexUsageHistoryIndexOperationLockRegistry()
    private static let stagingTestState = CodexUsageHistoryStagingTestState()
    private static let sessionCatalogPublishTestState =
        CodexSessionCatalogPublishTestState()
    private static let ephemeralRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexTokenBarSwift-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        .appendingPathComponent(indexNamespace, isDirectory: true)

    private let driver: SQLiteDatabaseDriver
    private let fileManager: FileManager
    private let operationGate: CodexUsageHistoryIndexOperationGate

    convenience init(codexHome: URL, fileManager: FileManager = .default) throws {
        let databaseURL = Self.databaseURL(for: codexHome)
        try self.init(databaseURL: databaseURL, fileManager: fileManager)
    }

    convenience init(
        sessionCatalogTestingDatabaseURL databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try self.init(databaseURL: databaseURL, fileManager: fileManager)
    }

    private init(databaseURL: URL, fileManager: FileManager) throws {
        self.fileManager = fileManager
        operationGate = Self.operationGate(for: databaseURL)
        driver = SQLiteDatabaseDriver(
            url: databaseURL,
            busyTimeoutMilliseconds: 30_000,
            enableWAL: true,
            fileManager: fileManager
        )
        try withExclusiveAccess {
            do {
                try prepareSchema()
                try validateIntegrity()
            } catch let error as SQLiteDatabaseError
                where Self.isRebuildableCorruption(error) {
                try? fileManager.removeItem(at: driver.url)
                try? fileManager.removeItem(atPath: driver.url.path + "-wal")
                try? fileManager.removeItem(atPath: driver.url.path + "-shm")
                try prepareSchema()
                try validateIntegrity()
            }
        }
    }

    static func withExclusiveAccess<T>(
        codexHome: URL,
        _ body: () throws -> T
    ) throws -> T {
        try operationGate(for: databaseURL(for: codexHome)).withLock(body)
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

    static func failNextImportAfterStagingForTesting() {
        stagingTestState.armFailure()
    }

    static func failNextSessionCatalogPublishForTesting() {
        sessionCatalogPublishTestState.armFailure()
    }

    // 冷建 heavy 文件阈值（与 Rust PARALLEL_HEAVY_FILE_BYTES 同值）。
    // 测试可注入小阈值，用小文件驱动 heavy/light 双通道调度行为。
    var coldBuildHeavyFileThreshold: UInt64 = 512 * 1_024 * 1_024

    func synchronize(
        files: [URL],
        sessionID: (URL) -> String,
        parser: @escaping SessionParser
    ) throws -> SynchronizationResult {
        try withExclusiveAccess {
            try synchronizeExclusively(files: files, sessionID: sessionID, parser: parser)
        }
    }

    func attributionState() throws -> AttributionState {
        try withExclusiveAccess {
            try driver.withConnection { connection in
                try configure(connection)
                return try currentAttributionState(connection: connection)
            }
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
        try withExclusiveAccess {
            try readSessionCatalogEntriesExclusively()
                .map(\.entry)
                .sorted { $0.path < $1.path }
        }
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
        parser: @escaping SessionParser
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

        try driver.withConnection { connection in
            try configure(connection)

            for file in canonicalFiles {
                try autoreleasepool {
                    let path = file.path
                    let observed = try sourceSignature(for: file)
                    let existing = try indexedSource(path: path, connection: connection)
                    if let existing,
                       existing.signature == observed {
                        unchangedFiles += 1
                        return
                    }

                    let parsedSessionID = sessionID(file)
                    if let existing,
                       canAttemptAppend(from: existing, to: observed),
                       let appended = try appendSource(
                           file: file,
                           sessionID: parsedSessionID,
                           observedSignature: observed,
                           existing: existing,
                           generation: generation,
                           connection: connection,
                           parser: parser
                       ) {
                        sourceMutationDetected = true
                        changedFiles += 1
                        indexedEvents += appended.eventCount
                        incrementallyParsedFiles += 1
                    } else {
                        if existing != nil {
                            rewrittenFiles += 1
                        }
                        fullRebuildJobs.append(
                            FullRebuildJob(
                                file: file,
                                sessionID: parsedSessionID,
                                observedSignature: observed
                            )
                        )
                    }
                }
            }
        }

        let stagedRebuilds = try stageFullRebuilds(
            fullRebuildJobs,
            parser: parser
        )
        if Self.stagingTestState.consumeFailure() {
            throw SQLiteDatabaseError(
                operation: "Injected exact usage staging interruption",
                code: SQLITE_ABORT,
                message: "Testing interruption after durable staging",
                path: driver.url.path
            )
        }
        var lineageReplacements: [String: LineageReplacement] = [:]
        var lineagesRequiringMaximumMerge = Set<String>()
        var provenanceRotated = false
        let finalAttributionState = try driver.withConnection { connection in
            try configure(connection)
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
            // Publish a new provenance epoch before any non-append replacement
            // or unprovable lineage replacement becomes visible. The rotation
            // transaction first copies the durable ledger, so interruption can
            // overestimate local usage but cannot silently reconcile ambiguity.
            let currentScanUnsafeCauseDetected = rewrittenFiles > 0
                || lineageAmbiguityDetected
            let preRotationAttributionState = try currentAttributionState(
                connection: connection
            )
            let unsafeEpisodeBegan = currentScanUnsafeCauseDetected
                && !preRotationAttributionState.currentScanUnsafeCauseDetected
            if currentScanUnsafeCauseDetected
                && !preRotationAttributionState.requiresSyntheticCutover {
                provenanceRotated = true
                _ = try rotateAttributionProvenance(
                    markUnsafe: true,
                    connection: connection
                )
            }
            for staged in stagedRebuilds {
                try importStagedFullRebuild(
                    staged,
                    generation: generation,
                    replacementSourceID: lineageReplacements[staged.job.file.path]?.sourceID,
                    preserveExistingAttributionLedger:
                        lineagesRequiringMaximumMerge.contains(staged.job.file.path),
                    connection: connection
                )
                changedFiles += 1
                indexedEvents += staged.eventCount
                sourceMutationDetected = true
                removeStagingDatabase(at: staged.databaseURL)
            }
            return try connection.transaction { transaction in
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
                removedFiles = removedSourceIDs.count
                sourceMutationDetected = sourceMutationDetected
                    || !removedSourceIDs.isEmpty
                for sourceID in removedSourceIDs {
                    try transaction.execute(
                        "DELETE FROM sources WHERE source_id = ?;",
                        bindings: [.int64(sourceID)]
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
                if unsafeEpisodeBegan {
                    try markAttributionUnsafe(
                        provenanceEpoch: current.provenanceEpoch,
                        sinceGeneration: publishedGeneration,
                        connection: transaction
                    )
                }
                return try currentAttributionState(connection: transaction)
            }
        }
        removeStagingDirectory()

        return SynchronizationResult(
            changedFiles: changedFiles,
            unchangedFiles: unchangedFiles,
            indexedEvents: indexedEvents,
            incrementallyParsedFiles: incrementallyParsedFiles,
            rewrittenFiles: rewrittenFiles,
            removedFiles: removedFiles,
            provenanceEpoch: finalAttributionState.provenanceEpoch,
            attributionGeneration: finalAttributionState.generation,
            attributionUnsafeSinceGeneration:
                finalAttributionState.unsafeSinceGeneration,
            lineageAmbiguityDetected: lineageAmbiguityDetected,
            attributionUnsafe: finalAttributionState.requiresSyntheticCutover
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
        try withExclusiveAccess {
            try driver.withConnection { connection in
                try configure(connection)
                return try connection.transaction { transaction in
                    let current = try currentAttributionState(connection: transaction)
                    guard current.provenanceEpoch == provenanceEpoch else {
                        throw SQLiteDatabaseError(
                            operation: "Read exact usage attribution ledger",
                            code: SQLITE_ABORT,
                            message: "Requested provenance epoch was superseded",
                            path: driver.url.path
                        )
                    }
                    return try transaction.readRows(
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
        }
    }

    // 决策口径：紧凑 surface 刷新只跑轻量聚合 SQL（累计 token、今日 token、
    // 今日调用数、今日逐模型用量），不得顺带构建时间序列/排行/摘录。
    func compactTotals(todayStart: Date) throws -> CompactTotals {
        try withExclusiveAccess {
            try driver.withConnection { connection in
                let total = try connection.readRows(
                    "SELECT COALESCE(SUM(tokens), 0) FROM events;"
                ) { row in row.int(0) ?? 0 }.first ?? 0
                let start = todayStart.timeIntervalSince1970
                let todayTokens = try connection.readRows(
                    "SELECT COALESCE(SUM(tokens), 0) FROM events WHERE timestamp >= ?;",
                    bindings: [.double(start)]
                ) { row in row.int(0) ?? 0 }.first ?? 0
                let todayCalls = try connection.readRows(
                    "SELECT COUNT(*) FROM events WHERE timestamp >= ?;",
                    bindings: [.double(start)]
                ) { row in row.int(0) ?? 0 }.first ?? 0
                let todayModelBreakdowns = try connection.readRows(
                    """
                    SELECT
                        model,
                        COALESCE(SUM(input_tokens), 0),
                        COALESCE(SUM(MIN(cached_input_tokens, input_tokens)), 0),
                        COALESCE(SUM(output_tokens), 0),
                        COALESCE(SUM(reasoning_output_tokens), 0),
                        COALESCE(SUM(tokens), 0),
                        COUNT(*)
                    FROM events
                    WHERE timestamp >= ?
                    GROUP BY model
                    ORDER BY SUM(tokens) DESC;
                    """,
                    bindings: [.double(start)]
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
    }

    func forEachStoredEvent(_ body: (StoredEvent) throws -> Void) throws {
        try withExclusiveAccess {
            try forEachStoredEventExclusively(body)
        }
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

    private static func isRebuildableCorruption(_ error: SQLiteDatabaseError) -> Bool {
        let primaryCode = error.code & 0xFF
        return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
    }

    private func prepareSchema() throws {
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

            if !destructiveRebuildRequired,
               currentVersion != nil {
                try migrateV2SourcesForAppend(connection)
                try migrateKnownEventColumns(connection)
                try repairExplicitSubagentReplayBoundary(connection)
            }

            // Capture all attribution evidence before any destructive schema
            // rebuild. A future/unknown schema version and a tombstoned ledger
            // can otherwise lose their only evidence before safety is decided.
            let storedProvenanceRevision = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = 'provenance_revision' LIMIT 1;"
            ) { row in row.text(0) }.first ?? nil
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
                CREATE INDEX IF NOT EXISTS sources_session
                    ON sources(session_id, source_id);
                CREATE INDEX IF NOT EXISTS sources_session_nocase
                    ON sources(session_id COLLATE NOCASE, source_id);

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
            if destructiveRebuildRequired
                || storedProvenanceRevision != Self.attributionProvenanceRevision {
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
            }
            try migrateV2SourcesForAppend(connection)
            try migrateKnownEventColumns(connection)
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

                INSERT INTO schema_meta(key, value)
                VALUES ('schema_version', '\(Self.schemaVersion)')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """
            )
            try prepareSessionCatalogSchema(connection)
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
            let current = try currentAttributionState(connection: transaction)
            let nextEpoch = UUID().uuidString
            try transaction.execute(
                "UPDATE schema_meta SET value = ? WHERE key = 'provenance_epoch';",
                bindings: [.text(nextEpoch)]
            )
            try transaction.execute(
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
            let generation = try bumpAttributionGeneration(connection: transaction)
            if markUnsafe {
                try markAttributionUnsafe(
                    provenanceEpoch: nextEpoch,
                    sinceGeneration: generation,
                    connection: transaction
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
            try connection.execute(
                """
                DROP TABLE IF EXISTS session_catalog_entries;
                DELETE FROM session_catalog_meta;
                """
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

    /// Marks only active replay sources whose first line proves an explicit
    /// subagent fork for an atomic single-file replacement on the next normal
    /// synchronization. The currently published rows remain readable until
    /// that replacement is committed; migration never deletes token events or
    /// rescans the full JSONL corpus.
    private func repairExplicitSubagentReplayBoundary(
        _ connection: SQLiteDatabaseConnection
    ) throws {
        let tableExists = try connection.readRows(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'sources';
            """
        ) { ($0.int(0) ?? 0) > 0 }.first ?? false
        guard tableExists else { return }
        let storedRevision = try connection.readRows(
            """
            SELECT value FROM schema_meta
            WHERE key = 'fork_replay_boundary_revision' LIMIT 1;
            """
        ) { $0.text(0) }.first ?? nil
        guard storedRevision != Self.forkReplayBoundaryRevision else { return }

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
            return
        }

        try connection.execute(
            """
            INSERT INTO schema_meta(key, value)
            VALUES ('fork_replay_boundary_revision', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [.text(Self.forkReplayBoundaryRevision)]
        )
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

    // 决策口径：PRAGMA quick_check 是全库扫描，且在 single-flight 门内执行，
    // 每进程每路径只跑一次；通过后记入进程级注册表，后续同路径建索引跳过。
    private final class IntegrityValidationRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var validatedPaths: Set<String> = []
        private var runCount = 0

        func isValidated(path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return validatedPaths.contains(path)
        }

        func recordRun() {
            lock.lock()
            runCount += 1
            lock.unlock()
        }

        func markValidated(path: String) {
            lock.lock()
            validatedPaths.insert(path)
            lock.unlock()
        }

        var runCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return runCount
        }
    }

    private static let integrityValidationRegistry = IntegrityValidationRegistry()

    static var integrityCheckRunCountForTesting: Int {
        integrityValidationRegistry.runCountForTesting
    }

    private func validateIntegrity() throws {
        let path = driver.url.path
        if Self.integrityValidationRegistry.isValidated(path: path) {
            return
        }
        Self.integrityValidationRegistry.recordRun()
        let results = try driver.readRows("PRAGMA quick_check;") { row in
            row.text(0) ?? ""
        }
        guard results == ["ok"] else {
            throw SQLiteDatabaseError(
                operation: "Validate exact usage index",
                code: SQLITE_CORRUPT,
                message: results.joined(separator: "; "),
                path: driver.url.path
            )
        }
        Self.integrityValidationRegistry.markValidated(path: path)
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
        let rows: [IndexedSource?] = try connection.readRows(
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
                audit_chunk_index
            FROM sources
            WHERE path = ?
            LIMIT 1;
            """,
            bindings: [.text(path)]
        ) { row in
            guard let sourceID = row.int64(0),
                  let rawSize = row.int64(1),
                  rawSize >= 0,
                  let modifiedAt = row.double(2),
                  let probe = row.text(3),
                  let rawDeviceID = row.text(4),
                  let deviceID = UInt64(rawDeviceID),
                  let rawInode = row.text(5),
                  let inode = UInt64(rawInode),
                  let statusChangedSeconds = row.int64(6),
                  let statusChangedNanoseconds = row.int64(7) else {
                return nil
            }
            let checkpoint: SourceCheckpoint?
            if row.int(8) == 1,
               let rawResumeOffset = row.int64(9),
               rawResumeOffset >= 0 {
                checkpoint = SourceCheckpoint(
                    resumeOffset: UInt64(rawResumeOffset),
                    parserState: CodexUsageAnalyzer.IndexedSessionParserState(
                        previousTotalTokens: row.int(10),
                        forkReplayStartedAt: row.double(11).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        isSkippingForkReplay: row.int(12) == 1,
                        isExplicitSubagentFork: row.int(13) == 1,
                        lastSkippedForkReplayTokenAt: row.double(14).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        currentUserPromptOffset: row.int64(15).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        assistantStartOffset: row.int64(16).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        currentModel: row.text(17)
                    ),
                    auditChunkIndex: row.int64(18).flatMap {
                        $0 >= 0 ? UInt64($0) : nil
                    } ?? 0
                )
            } else {
                checkpoint = nil
            }
            return IndexedSource(
                id: sourceID,
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
        return rows.compactMap { $0 }.first
    }

    private func indexedSourceIdentities(
        connection: SQLiteDatabaseConnection
    ) throws -> [SourceIdentity] {
        try connection.readRows(
            "SELECT source_id, path FROM sources ORDER BY source_id;"
        ) { row -> SourceIdentity? in
            guard let sourceID = row.int64(0),
                  let path = row.text(1) else {
                return nil
            }
            return SourceIdentity(id: sourceID, path: path)
        }.compactMap { $0 }
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
        observedSignature: SourceSignature,
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
        let hashingStartOffset = (tailChunkIndex ?? 0) * Self.chunkSize
        // 活动文件的未完成行可以合法地跨过块边界：此时续扫起点（resumeOffset，
        // 未完成行的行首）落在尾块起点之前，续扫不变量无法满足。必须回退全量
        // 重建（返回 nil）而不是让流式层抛错——抛错会使整轮同步失败，检查点
        // 固化后每轮复现，该 Home 的精确统计将永久停摆无自愈。
        guard checkpoint.resumeOffset >= hashingStartOffset else { return nil }

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
                        endOffset: observedSignature.size,
                        validationBoundary: existing.signature.size,
                        initialState: checkpoint.parserState
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

                guard result.lastOffset == observedSignature.size else {
                    throw CodexUsageSourceChangedError(path: file.path)
                }
                if existing.signature.size > 0,
                   result.validationChunkHash != storedTail {
                    throw AppendCheckpointError.rejected
                }
                try validateAppendScan(
                    file: file,
                    observedSignature: observedSignature,
                    chunkHashes: result.chunkHashes
                )
                try replaceSourceChunks(
                    sourceID: existing.id,
                    startingAt: tailChunkIndex ?? 0,
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
                    signature: observedSignature,
                    generation: generation,
                    parseResult: result,
                    auditChunkIndex: nextAuditChunk,
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
        let (offset, overflow) = index.multipliedReportingOverflow(by: Self.chunkSize)
        guard !overflow else {
            throw CodexUsageSourceChangedError(path: file.path)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var remaining = byteCount
        var hasher = SHA256()
        while remaining > 0 {
            let data = handle.readData(ofLength: Int(min(remaining, 1_048_576)))
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
        observedSignature: SourceSignature,
        chunkHashes: [CodexUsageAnalyzer.IndexedChunkHash]
    ) throws {
        let finalSignature = try sourceSignature(for: file)
        guard finalSignature != observedSignature else { return }
        guard finalSignature.deviceID == observedSignature.deviceID,
              finalSignature.inode == observedSignature.inode,
              finalSignature.size >= observedSignature.size else {
            throw CodexUsageSourceChangedError(path: file.path)
        }
        guard observedSignature.size > 0 else { return }
        let tailIndex = (observedSignature.size - 1) / Self.chunkSize
        let byteCount = observedSignature.size - tailIndex * Self.chunkSize
        guard let scannedTail = chunkHashes.first(where: { $0.index == tailIndex }),
              try hashSourceChunk(
                  file: file,
                  index: tailIndex,
                  byteCount: byteCount
              ) == scannedTail,
              finalSignature.size > observedSignature.size else {
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

        func append(_ value: StagedFullRebuild) {
            lock.lock()
            values.append(value)
            lock.unlock()
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

    private func stageFullRebuilds(
        _ jobs: [FullRebuildJob],
        parser: @escaping SessionParser
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

        for job in jobs {
            let queue = job.observedSignature.size >= heavyThreshold ? heavyQueue : lightQueue
            queue.addOperation { [self] in
                autoreleasepool {
                    do {
                        collector.append(
                            try stageFullRebuild(job, parser: parserBox.parser)
                        )
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
                    complete INTEGER PRIMARY KEY,
                    session_id TEXT NOT NULL,
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
                    current_model TEXT
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
            return try connection.transaction { transaction in
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
                    .full(endOffset: job.observedSignature.size),
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
                guard result.lastOffset == job.observedSignature.size else {
                    throw CodexUsageSourceChangedError(path: job.file.path)
                }
                let finalSignature = try sourceSignature(for: job.file)
                let committedSignature: SourceSignature
                if finalSignature == job.observedSignature {
                    committedSignature = finalSignature
                } else if finalSignature.deviceID == job.observedSignature.deviceID,
                          finalSignature.inode == job.observedSignature.inode,
                          finalSignature.size >= job.observedSignature.size,
                          try contentHash(
                              for: job.file,
                              length: job.observedSignature.size
                          ) == result.contentHash {
                    committedSignature = finalSignature.size == job.observedSignature.size
                        ? finalSignature
                        : job.observedSignature
                } else {
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
                try transaction.execute(
                    """
                    INSERT INTO manifest(
                        complete,
                        session_id,
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
                        current_model
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .text(job.sessionID),
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
                        state.currentModel.map(SQLiteBinding.text) ?? .null
                    ]
                )
                return StagedFullRebuild(
                    job: job,
                    databaseURL: databaseURL,
                    committedSignature: committedSignature,
                    eventCount: result.eventCount,
                    resumeOffset: result.resumeOffset,
                    parserState: result.state
                )
            }
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
                    session_id,
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
                    current_model
                FROM manifest
                WHERE complete = 1
                LIMIT 1;
                """
            ) { row in
                guard row.text(0) == job.sessionID,
                      let rawSize = row.int64(1),
                      rawSize >= 0,
                      let modifiedAt = row.double(2),
                      let contentProbe = row.text(3),
                      let deviceID = row.text(4).flatMap(UInt64.init),
                      let inode = row.text(5).flatMap(UInt64.init),
                      let changedSeconds = row.int64(6),
                      let changedNanoseconds = row.int64(7),
                      let eventCount = row.int(8),
                      let rawResumeOffset = row.int64(9),
                      rawResumeOffset >= 0 else {
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
                guard signature == job.observedSignature else {
                    return nil
                }
                return StagedFullRebuild(
                    job: job,
                    databaseURL: databaseURL,
                    committedSignature: signature,
                    eventCount: eventCount,
                    resumeOffset: UInt64(rawResumeOffset),
                    parserState: CodexUsageAnalyzer.IndexedSessionParserState(
                        previousTotalTokens: row.int(10),
                        forkReplayStartedAt: row.double(11).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        isSkippingForkReplay: row.int(12) == 1,
                        isExplicitSubagentFork: row.int(13) == 1,
                        lastSkippedForkReplayTokenAt: row.double(14).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        currentUserPromptOffset: row.int64(15).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        assistantStartOffset: row.int64(16).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        currentModel: row.text(17)
                    )
                )
            }
            if let reusable = rows.compactMap({ $0 }).first {
                return reusable
            }
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
            return SourceIdentity(id: sourceID, path: path)
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

    private func importStagedFullRebuild(
        _ staged: StagedFullRebuild,
        generation: String,
        replacementSourceID: Int64?,
        preserveExistingAttributionLedger: Bool,
        connection: SQLiteDatabaseConnection
    ) throws {
        let stage = SQLiteDatabaseDriver(
            url: staged.databaseURL,
            readOnly: true,
            busyTimeoutMilliseconds: 1_000,
            fileManager: fileManager
        )
        try connection.transaction { transaction in
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
            try stage.forEachRow("SELECT value FROM fingerprints ORDER BY value;") { row in
                guard let value = row.text(0) else { return }
                _ = try fingerprintStatement.execute([
                    .int64(source.id),
                    .text(value)
                ])
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
                    return
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
            }
            let chunkStatement = try transaction.prepare(
                """
                INSERT INTO source_chunks(source_id, chunk_index, byte_count, sha256)
                VALUES (?, ?, ?, ?);
                """
            )
            try stage.forEachRow(
                "SELECT chunk_index, byte_count, sha256 FROM chunks ORDER BY chunk_index;"
            ) { row in
                guard let chunkIndex = row.int64(0),
                      let byteCount = row.int64(1),
                      let sha256 = row.text(2) else {
                    return
                }
                _ = try chunkStatement.execute([
                    .int64(source.id),
                    .int64(chunkIndex),
                    .int64(byteCount),
                    .text(sha256)
                ])
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
        }
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

    private func sourceSignature(for file: URL) throws -> SourceSignature {
        var fileStatus = Darwin.stat()
        guard lstat(file.path, &fileStatus) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let values = try file.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey
        ])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let size = UInt64(fileSize)
        return SourceSignature(
            size: size,
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            contentProbe: try contentProbe(for: file, size: size),
            deviceID: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            statusChangedSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            statusChangedNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
    }

    private func contentHash(for file: URL, length: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

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

private final class WeakOperationGate {
    weak var value: CodexUsageHistoryIndexOperationGate?

    init(_ value: CodexUsageHistoryIndexOperationGate) {
        self.value = value
    }
}

private final class CodexUsageHistoryStagingTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextImport = false

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
                crossProcessLock = try CodexCrossProcessFileLock(
                    url: crossProcessLockURL,
                    label: "精确历史索引"
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
