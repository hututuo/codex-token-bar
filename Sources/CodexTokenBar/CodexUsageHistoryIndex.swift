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
        var lastSkippedForkReplayTokenAt: Date?
        var currentUserPromptOffset: UInt64?
        var assistantStartOffset: UInt64?

        static let empty = IndexedSessionParserState(
            previousTotalTokens: nil,
            forkReplayStartedAt: nil,
            isSkippingForkReplay: false,
            lastSkippedForkReplayTokenAt: nil,
            currentUserPromptOffset: nil,
            assistantStartOffset: nil
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
    }

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

    private struct SourceCheckpoint {
        let resumeOffset: UInt64
        let parserState: CodexUsageAnalyzer.IndexedSessionParserState
        let auditChunkIndex: UInt64
    }

    private struct SourceUpdateResult {
        let parseResult: CodexUsageAnalyzer.IndexedSessionParseResult
        let incremental: Bool
    }

    private enum AppendCheckpointError: Error {
        case rejected
    }

    private static let schemaVersion = "3"
    private static let legacyAppendMigrationSchemaVersion = "2"
    private static let chunkSize: UInt64 = 4 * 1_024 * 1_024
    private static let cacheDirectoryName = "CodexTokenBarSwift"
    private static let indexNamespace = "exact-usage-history-v1"
    private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"
    private static let disabledCacheEnvironmentKey = "CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE"
    private static let operationLocks = CodexUsageHistoryIndexOperationLockRegistry()
    private static let ephemeralRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexTokenBarSwift-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        .appendingPathComponent(indexNamespace, isDirectory: true)

    private let driver: SQLiteDatabaseDriver
    private let fileManager: FileManager
    private let operationGate: CodexUsageHistoryIndexOperationGate

    init(codexHome: URL, fileManager: FileManager = .default) throws {
        let databaseURL = Self.databaseURL(for: codexHome)
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
    ) rethrows -> T {
        try operationGate(for: databaseURL(for: codexHome)).withLock(body)
    }

    func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        try operationGate.withLock(body)
    }

    static func waitForExclusiveAccessWaiterForTesting(
        codexHome: URL,
        timeout: TimeInterval
    ) -> Bool {
        operationGate(for: databaseURL(for: codexHome))
            .waitForPendingAcquisition(timeout: timeout)
    }

    func synchronize(
        files: [URL],
        sessionID: (URL) -> String,
        parser: SessionParser
    ) throws -> SynchronizationResult {
        try withExclusiveAccess {
            try synchronizeExclusively(files: files, sessionID: sessionID, parser: parser)
        }
    }

    private func synchronizeExclusively(
        files: [URL],
        sessionID: (URL) -> String,
        parser: SessionParser
    ) throws -> SynchronizationResult {
        let generation = UUID().uuidString
        var changedFiles = 0
        var unchangedFiles = 0
        var indexedEvents = 0
        var incrementallyParsedFiles = 0

        try driver.withConnection { connection in
            try configure(connection)
            try connection.execute(
                "CREATE TEMP TABLE IF NOT EXISTS scan_fingerprints (value TEXT PRIMARY KEY) WITHOUT ROWID;"
            )

            for file in files {
                try autoreleasepool {
                    let canonicalFile = file.resolvingSymlinksInPath()
                    let path = canonicalFile.path
                    let observed = try sourceSignature(for: canonicalFile)
                    let existing = try indexedSource(path: path, connection: connection)
                    if let existing,
                       existing.signature == observed {
                        try connection.execute(
                            "UPDATE sources SET last_seen_generation = ? WHERE source_id = ?;",
                            bindings: [.text(generation), .int64(existing.id)]
                        )
                        unchangedFiles += 1
                        return
                    }

                    let parsedSessionID = sessionID(canonicalFile)
                    let result: SourceUpdateResult
                    if let existing,
                       canAttemptAppend(from: existing, to: observed),
                       let appended = try appendSource(
                           file: canonicalFile,
                           sessionID: parsedSessionID,
                           observedSignature: observed,
                           existing: existing,
                           generation: generation,
                           connection: connection,
                           parser: parser
                       ) {
                        result = SourceUpdateResult(
                            parseResult: appended,
                            incremental: true
                        )
                    } else {
                        result = SourceUpdateResult(
                            parseResult: try rebuildSource(
                                file: canonicalFile,
                                sessionID: parsedSessionID,
                                observedSignature: observed,
                                generation: generation,
                                connection: connection,
                                parser: parser
                            ),
                            incremental: false
                        )
                    }
                    changedFiles += 1
                    indexedEvents += result.parseResult.eventCount
                    if result.incremental {
                        incrementallyParsedFiles += 1
                    }
                }
            }

            try connection.transaction { transaction in
                try transaction.execute(
                    "DELETE FROM sources WHERE last_seen_generation <> ?;",
                    bindings: [.text(generation)]
                )
            }
        }

        return SynchronizationResult(
            changedFiles: changedFiles,
            unchangedFiles: unchangedFiles,
            indexedEvents: indexedEvents,
            incrementallyParsedFiles: incrementallyParsedFiles
        )
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
                events.reasoning_output_tokens
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

            if currentVersion != nil,
               currentVersion != Self.schemaVersion,
               currentVersion != Self.legacyAppendMigrationSchemaVersion {
                try connection.execute(
                    """
                    DROP TABLE IF EXISTS source_chunks;
                    DROP TABLE IF EXISTS source_fingerprints;
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
                    last_skipped_fork_replay_token_at REAL,
                    current_user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER,
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
                """
            )
            try migrateV2SourcesForAppend(connection)
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
        }
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
            ("last_skipped_fork_replay_token_at", "REAL"),
            ("current_user_prompt_offset", "INTEGER"),
            ("assistant_start_offset", "INTEGER"),
            ("audit_chunk_index", "INTEGER NOT NULL DEFAULT 0")
        ]
        for (column, definition) in additions where !existingColumns.contains(column) {
            try connection.execute(
                "ALTER TABLE sources ADD COLUMN \(column) \(definition);"
            )
        }
    }

    private func validateIntegrity() throws {
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
                last_skipped_fork_replay_token_at,
                current_user_prompt_offset,
                assistant_start_offset,
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
                        lastSkippedForkReplayTokenAt: row.double(13).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        currentUserPromptOffset: row.int64(14).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        assistantStartOffset: row.int64(15).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        }
                    ),
                    auditChunkIndex: row.int64(16).flatMap {
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

        do {
            return try connection.transaction { transaction in
                try transaction.execute("DELETE FROM scan_fingerprints;")
                try transaction.execute(
                    """
                    INSERT OR IGNORE INTO scan_fingerprints(value)
                    SELECT value FROM source_fingerprints WHERE source_id = ?;
                    """,
                    bindings: [.int64(existing.id)]
                )
                let fingerprintStatement = try transaction.prepare(
                    "INSERT OR IGNORE INTO scan_fingerprints(value) VALUES (?);"
                )
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
                        user_prompt_offset,
                        assistant_start_offset
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                        let inserted = try fingerprintStatement.execute([.text(key)]) > 0
                        if inserted {
                            _ = try persistentFingerprintStatement.execute([
                                .int64(existing.id),
                                .text(key)
                            ])
                        }
                        return inserted
                    },
                    { indexedEvent in
                        let event = indexedEvent.event
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
                last_skipped_fork_replay_token_at = ?,
                current_user_prompt_offset = ?,
                assistant_start_offset = ?,
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
                state.lastSkippedForkReplayTokenAt.map(SQLiteBinding.date) ?? .null,
                try state.currentUserPromptOffset.map {
                    .int64(try sqliteInt64($0))
                } ?? .null,
                try state.assistantStartOffset.map {
                    .int64(try sqliteInt64($0))
                } ?? .null,
                .int64(try sqliteInt64(auditChunkIndex)),
                .int64(sourceID)
            ]
        )
    }

    private func rebuildSource(
        file: URL,
        sessionID: String,
        observedSignature: SourceSignature,
        generation: String,
        connection: SQLiteDatabaseConnection,
        parser: SessionParser
    ) throws -> CodexUsageAnalyzer.IndexedSessionParseResult {
        try connection.transaction { transaction in
            try transaction.execute(
                """
                INSERT INTO sources(
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
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    session_id = excluded.session_id,
                    last_seen_generation = excluded.last_seen_generation;
                """,
                bindings: [
                    .text(file.path),
                    .text(sessionID),
                    .int64(try sqliteInt64(observedSignature.size)),
                    .double(observedSignature.modifiedAt),
                    .text(observedSignature.contentProbe),
                    .text(String(observedSignature.deviceID)),
                    .text(String(observedSignature.inode)),
                    .int64(observedSignature.statusChangedSeconds),
                    .int64(observedSignature.statusChangedNanoseconds),
                    .text(generation)
                ]
            )
            guard let source = try indexedSource(path: file.path, connection: transaction) else {
                throw SQLiteDatabaseError(
                    operation: "Resolve exact usage source",
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
            try transaction.execute("DELETE FROM scan_fingerprints;")

            let fingerprintStatement = try transaction.prepare(
                "INSERT OR IGNORE INTO scan_fingerprints(value) VALUES (?);"
            )
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
                    user_prompt_offset,
                    assistant_start_offset
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )

            let result = try parser(
                file,
                sessionID,
                .full(endOffset: observedSignature.size),
                { fingerprint in
                    let key = fingerprint.databaseKey
                    let inserted = try fingerprintStatement.execute([.text(key)]) > 0
                    if inserted {
                        _ = try persistentFingerprintStatement.execute([
                            .int64(source.id),
                            .text(key)
                        ])
                    }
                    return inserted
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
                    try eventStatement.execute([
                        .int64(source.id),
                        .int64(try sqliteInt64(indexedEvent.sourceOffset)),
                        .date(event.timestamp),
                        .int(event.tokens),
                        .int(event.inputTokens),
                        .int(min(event.cachedInputTokens, event.inputTokens)),
                        .int(event.outputTokens),
                        .int(event.reasoningOutputTokens),
                        userPromptOffset,
                        assistantStartOffset
                    ])
                }
            )

            let finalSignature = try sourceSignature(for: file)
            guard result.lastOffset == observedSignature.size else {
                throw CodexUsageSourceChangedError(path: file.path)
            }
            let committedSignature: SourceSignature
            if finalSignature == observedSignature {
                committedSignature = finalSignature
            } else if finalSignature.deviceID == observedSignature.deviceID,
                      finalSignature.inode == observedSignature.inode,
                      finalSignature.size >= observedSignature.size,
                      try contentHash(for: file, length: observedSignature.size) == result.contentHash {
                // Codex appends to the active JSONL while a refresh is running. The parser reads
                // exactly the size observed at the start, so this commits a complete point-in-time
                // prefix instead of aborting the entire history scan. The deliberately older stored
                // signature makes the next refresh pick up bytes appended after that boundary.
                committedSignature = finalSignature.size == observedSignature.size
                    ? finalSignature
                    : observedSignature
            } else {
                throw CodexUsageSourceChangedError(path: file.path)
            }
            try replaceSourceChunks(
                sourceID: source.id,
                startingAt: 0,
                chunks: result.chunkHashes,
                connection: transaction
            )
            try saveSourceCheckpoint(
                sourceID: source.id,
                sessionID: sessionID,
                signature: committedSignature,
                generation: generation,
                parseResult: result,
                auditChunkIndex: 0,
                connection: transaction
            )
            return result
        }
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
    private var locks: [String: CodexUsageHistoryIndexOperationGate] = [:]

    func lock(for path: String) -> CodexUsageHistoryIndexOperationGate {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path] {
            return existing
        }
        let created = CodexUsageHistoryIndexOperationGate(name: path)
        locks[path] = created
        return created
    }
}

private final class CodexUsageHistoryIndexOperationGate: @unchecked Sendable {
    private let recursiveLock = NSRecursiveLock()
    private let state = NSCondition()
    private var pendingAcquisitions = 0

    init(name: String) {
        recursiveLock.name = "CodexUsageHistoryIndex.\(name)"
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        state.lock()
        pendingAcquisitions += 1
        state.broadcast()
        state.unlock()

        recursiveLock.lock()

        state.lock()
        pendingAcquisitions -= 1
        state.broadcast()
        state.unlock()

        defer { recursiveLock.unlock() }
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
