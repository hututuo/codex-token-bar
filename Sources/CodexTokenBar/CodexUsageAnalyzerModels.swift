import Foundation

extension CodexUsageAnalyzer {
    struct UsageSnapshotFingerprint: Hashable, Codable {
        let totalInputTokens: Int
        let totalCachedInputTokens: Int
        let totalOutputTokens: Int
        let totalReasoningOutputTokens: Int
        let totalTokens: Int
        let hasLastUsage: Bool
        let lastInputTokens: Int
        let lastCachedInputTokens: Int
        let lastOutputTokens: Int
        let lastReasoningOutputTokens: Int
        let lastTokens: Int

        init(total: ParsedTokenUsage, last: ParsedTokenUsage?) {
            totalInputTokens = total.inputTokens
            totalCachedInputTokens = total.cachedInputTokens
            totalOutputTokens = total.outputTokens
            totalReasoningOutputTokens = total.reasoningOutputTokens
            totalTokens = total.totalTokens
            hasLastUsage = last != nil
            lastInputTokens = last?.inputTokens ?? 0
            lastCachedInputTokens = last?.cachedInputTokens ?? 0
            lastOutputTokens = last?.outputTokens ?? 0
            lastReasoningOutputTokens = last?.reasoningOutputTokens ?? 0
            lastTokens = last?.totalTokens ?? 0
        }

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            totalInputTokens = try values.decode(Int.self)
            totalCachedInputTokens = try values.decode(Int.self)
            totalOutputTokens = try values.decode(Int.self)
            totalReasoningOutputTokens = try values.decode(Int.self)
            totalTokens = try values.decode(Int.self)
            hasLastUsage = try values.decode(Int.self) != 0
            lastInputTokens = try values.decode(Int.self)
            lastCachedInputTokens = try values.decode(Int.self)
            lastOutputTokens = try values.decode(Int.self)
            lastReasoningOutputTokens = try values.decode(Int.self)
            lastTokens = try values.decode(Int.self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: values,
                    debugDescription: "Token usage fingerprint has an unexpected length"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(totalInputTokens)
            try values.encode(totalCachedInputTokens)
            try values.encode(totalOutputTokens)
            try values.encode(totalReasoningOutputTokens)
            try values.encode(totalTokens)
            try values.encode(hasLastUsage ? 1 : 0)
            try values.encode(lastInputTokens)
            try values.encode(lastCachedInputTokens)
            try values.encode(lastOutputTokens)
            try values.encode(lastReasoningOutputTokens)
            try values.encode(lastTokens)
        }
    }

    struct SessionCacheKey: Codable, Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
        let deviceID: UInt64?
        let inode: UInt64?
        let statusChangedSeconds: Int64?
        let statusChangedNanoseconds: Int64?
    }

    struct SessionTreeSignature: Codable, Equatable {
        let localDate: String
        let utcOffsetSeconds: Int
        let files: [SessionCacheKey]
        let stateDatabase: SessionCacheKey?
        let attributionProvenanceEpoch: String
        let attributionGeneration: Int64

        func withAttributionState(
            provenanceEpoch: String,
            generation: Int64
        ) -> SessionTreeSignature {
            SessionTreeSignature(
                localDate: localDate,
                utcOffsetSeconds: utcOffsetSeconds,
                files: files,
                stateDatabase: stateDatabase,
                attributionProvenanceEpoch: provenanceEpoch,
                attributionGeneration: generation
            )
        }
    }

    final class SessionEventCache: @unchecked Sendable {
        // Version 10 invalidates token events produced by the old single-counter delta logic.
        private static let persistentCacheVersion = 10
        private static let legacyPersistentCacheVersion = 8
        private static let appCacheDirectoryName = "CodexTokenBarSwift"
        static let cacheNamespace = "exact-usage-history-v1"
        static let previousCacheNamespace = "swift-usage-cache-2026-07-v4"
        private static let legacyMigrationMarkerName = ".v8-migration-complete"
        private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"

        private struct PersistentSessionMetadata: Codable {
            let version: Int
            let path: String
            let size: UInt64
            let modifiedAt: TimeInterval
            let lastOffset: UInt64
            let endedWithNewline: Bool
            let previousTotalTokens: Int?
            let canIncrementFromOffset: Bool
            let forkReplayActive: Bool
            let lastSkippedForkReplayTokenAt: TimeInterval?
            let recentUsageFingerprints: [UsageSnapshotFingerprint]
            let eventCount: Int
        }

        private struct LegacyPersistentSessionFile: Codable {
            let version: Int
            let entry: LegacyPersistentEntry
        }

        private struct LegacyPersistentEntry: Codable {
            let path: String
            let size: UInt64
            let modifiedAt: TimeInterval
            let lastOffset: UInt64
            let endedWithNewline: Bool
            let previousTotalTokens: Int?
            let canIncrementFromOffset: Bool
            let forkReplayActive: Bool
            let lastSkippedForkReplayTokenAt: TimeInterval?
            // Intentionally required: caches created before snapshot de-duplication must be rebuilt.
            let recentUsageFingerprints: [UsageSnapshotFingerprint]
            let events: [PersistentEvent]
        }

        struct PersistentEvent: Codable {
            let timestamp: TimeInterval
            let sessionID: String
            let model: String?
            let tokens: Int
            let inputTokens: Int
            let cachedInputTokens: Int
            let outputTokens: Int
            let reasoningOutputTokens: Int
            let userPromptDigest: String?
            let assistantResponseDigest: String?
        }

        struct CachedSession {
            let key: SessionCacheKey
            let events: [TokenEvent]
            let lastOffset: UInt64
            let endedWithNewline: Bool
            let previousTotalTokens: Int?
            let canIncrementFromOffset: Bool
            let forkReplayActive: Bool
            let lastSkippedForkReplayTokenAt: Date?
            let recentUsageFingerprints: [UsageSnapshotFingerprint]
            init(
                key: SessionCacheKey,
                events: [TokenEvent],
                lastOffset: UInt64,
                endedWithNewline: Bool,
                previousTotalTokens: Int?,
                canIncrementFromOffset: Bool,
                forkReplayActive: Bool,
                lastSkippedForkReplayTokenAt: Date?,
                recentUsageFingerprints: [UsageSnapshotFingerprint] = []
            ) {
                self.key = key
                self.events = events
                self.lastOffset = lastOffset
                self.endedWithNewline = endedWithNewline
                self.previousTotalTokens = previousTotalTokens
                self.canIncrementFromOffset = canIncrementFromOffset
                self.forkReplayActive = forkReplayActive
                self.lastSkippedForkReplayTokenAt = lastSkippedForkReplayTokenAt
                self.recentUsageFingerprints = recentUsageFingerprints
            }

            func strippingConversationExcerpts() -> CachedSession {
                CachedSession(
                    key: key,
                    events: events.map { $0.strippingConversationExcerpt() },
                    lastOffset: lastOffset,
                    endedWithNewline: endedWithNewline,
                    previousTotalTokens: previousTotalTokens,
                    canIncrementFromOffset: canIncrementFromOffset,
                    forkReplayActive: forkReplayActive,
                    lastSkippedForkReplayTokenAt: lastSkippedForkReplayTokenAt,
                    recentUsageFingerprints: recentUsageFingerprints
                )
            }
        }

        private let lock = NSLock()
        private var storage: [String: CachedSession] = [:]
        private var snapshotStorage: [String: (signature: SessionTreeSignature, snapshot: DashboardSnapshot)] = [:]
        private var snapshotBuildCount = 0
        private var fullSessionParseCount = 0
        private var incrementalSessionParseCount = 0
        private var didLoadPersistentCache = false
        private var pendingPersistence: [String: PersistenceOperation] = [:]
        private var deletedPersistentPaths = Set<String>()
        private var isSnapshotDirty = false
        private var shouldFinalizeLegacyV8Migration = false
        private var legacyV8MigrationFailed = false
        private let persistenceLock = NSLock()

        private enum PersistenceOperation {
            case replace
            case append(fromEventIndex: Int)
        }

        @available(*, unavailable, message: "Exact history must use CodexUsageHistoryIndex")
        func cachedSession(for path: String, key: SessionCacheKey) -> CachedSession? {
            loadPersistentCacheIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            guard let cached = storage[path], Self.keysMatch(cached.key, key) else {
                return nil
            }
            return cached
        }

        @available(*, unavailable, message: "Exact history must use CodexUsageHistoryIndex")
        func appendableSession(for path: String, currentKey: SessionCacheKey) -> CachedSession? {
            loadPersistentCacheIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            guard let cached = storage[path],
                  cached.canIncrementFromOffset,
                  cached.endedWithNewline,
                  cached.key.size < currentKey.size,
                  cached.lastOffset <= cached.key.size,
                  cached.lastOffset <= currentKey.size,
                  cached.previousTotalTokens != nil else {
                return nil
            }
            return cached
        }

        @available(*, unavailable, message: "Exact history must use CodexUsageHistoryIndex")
        func store(
            _ session: CachedSession,
            for path: String,
            appendingFromEventIndex: Int? = nil
        ) {
            // The live cache must follow the same privacy and memory contract as
            // the persisted cache. Snapshot candidates retain the few excerpts
            // the ranking UI can actually display; historical cache entries do not.
            let session = session.strippingConversationExcerpts()
            loadPersistentCacheIfNeeded()
            lock.lock()
            storage[path] = session
            let operation: PersistenceOperation
            if let appendingFromEventIndex,
               appendingFromEventIndex >= 0,
               appendingFromEventIndex <= session.events.count {
                operation = .append(fromEventIndex: appendingFromEventIndex)
            } else {
                operation = .replace
            }
            switch (pendingPersistence[path], operation) {
            case (.replace?, _), (_, .replace):
                pendingPersistence[path] = .replace
            case let (.append(fromEventIndex: existingIndex)?, .append(fromEventIndex: newIndex)):
                pendingPersistence[path] = .append(fromEventIndex: min(existingIndex, newIndex))
            case (nil, .append):
                pendingPersistence[path] = operation
            }
            deletedPersistentPaths.remove(path)
            lock.unlock()
        }

        @available(*, unavailable, message: "Exact history must use CodexUsageHistoryIndex")
        func retainOnly(paths: Set<String>) {
            loadPersistentCacheIfNeeded()
            lock.lock()
            let removed = Set(storage.keys).subtracting(paths)
            for path in removed {
                storage.removeValue(forKey: path)
                deletedPersistentPaths.insert(path)
                pendingPersistence.removeValue(forKey: path)
            }
            lock.unlock()
        }

        func snapshot(for root: String, signature: SessionTreeSignature) -> DashboardSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let cached = snapshotStorage[root], cached.signature == signature else {
                return nil
            }
            return cached.snapshot
        }

        func storeSnapshot(_ snapshot: DashboardSnapshot, for root: String, signature: SessionTreeSignature) {
            lock.lock()
            snapshotStorage[root] = (signature, snapshot)
            isSnapshotDirty = true
            lock.unlock()
        }

        func recordSnapshotBuildForTesting() {
            lock.lock()
            snapshotBuildCount += 1
            lock.unlock()
        }

        func recordFullSessionParseForTesting() {
            lock.lock()
            fullSessionParseCount += 1
            lock.unlock()
        }

        func recordIncrementalSessionParseForTesting() {
            lock.lock()
            incrementalSessionParseCount += 1
            lock.unlock()
        }

        var snapshotBuildCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return snapshotBuildCount
        }

        var fullSessionParseCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return fullSessionParseCount
        }

        var incrementalSessionParseCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return incrementalSessionParseCount
        }

        func resetSnapshotBuildCountForTesting() {
            lock.lock()
            snapshotBuildCount = 0
            fullSessionParseCount = 0
            incrementalSessionParseCount = 0
            lock.unlock()
        }

        func clearForTesting() {
            lock.lock()
            storage.removeAll()
            snapshotStorage.removeAll()
            snapshotBuildCount = 0
            fullSessionParseCount = 0
            incrementalSessionParseCount = 0
            didLoadPersistentCache = false
            pendingPersistence.removeAll()
            deletedPersistentPaths.removeAll()
            isSnapshotDirty = false
            shouldFinalizeLegacyV8Migration = false
            legacyV8MigrationFailed = false
            lock.unlock()
        }

        func clearSnapshotsForTesting() {
            lock.lock()
            snapshotStorage.removeAll()
            lock.unlock()
        }

        @available(*, unavailable, message: "Exact history must use CodexUsageHistoryIndex")
        func flushPersistentCache() {
            let trace = RefreshPerformanceProbe.begin("usageCache.flushPersistent")
            lock.lock()
            if CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled {
                pendingPersistence.removeAll()
                deletedPersistentPaths.removeAll()
                isSnapshotDirty = false
                lock.unlock()
                trace?.end("disabled")
                return
            }
            let pendingPersistence = pendingPersistence
            let deletedPersistentPaths = deletedPersistentPaths
            let dirtySessions = pendingPersistence.compactMap { path, operation in
                storage[path].map { (path, $0, operation) }
            }
            let shouldRemovePersistentSnapshot = isSnapshotDirty
            let shouldFinalizeLegacyV8Migration = shouldFinalizeLegacyV8Migration
                && !legacyV8MigrationFailed
            guard !dirtySessions.isEmpty
                    || !deletedPersistentPaths.isEmpty
                    || shouldRemovePersistentSnapshot
                    || shouldFinalizeLegacyV8Migration else {
                lock.unlock()
                trace?.end("clean")
                return
            }
            self.pendingPersistence.removeAll()
            self.deletedPersistentPaths.removeAll()
            isSnapshotDirty = false
            lock.unlock()

            guard let cacheDirectory = Self.sessionCacheDirectory else {
                trace?.end("no-cache-directory")
                return
            }
            persistenceLock.lock()
            defer { persistenceLock.unlock() }
            do {
                trace?.mark("removeLegacy.begin")
                Self.removeLegacyCaches()
                trace?.mark("removeLegacy.end")
                if let snapshotURL = Self.snapshotCacheURL {
                    trace?.mark("removePersistentSnapshot.begin")
                    try? FileManager.default.removeItem(at: snapshotURL)
                    trace?.mark("removePersistentSnapshot.end")
                }
                guard !dirtySessions.isEmpty
                        || !deletedPersistentPaths.isEmpty
                        || shouldFinalizeLegacyV8Migration else {
                    trace?.end("removed-snapshot-only")
                    return
                }
                trace?.mark("createDirectory.begin")
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                trace?.mark("createDirectory.end")
                trace?.mark("deleteShards.begin", metadata: ["count": String(deletedPersistentPaths.count)])
                for path in deletedPersistentPaths {
                    try? FileManager.default.removeItem(at: Self.sessionMetadataURL(for: path, in: cacheDirectory))
                    try? FileManager.default.removeItem(at: Self.sessionEventsURL(for: path, in: cacheDirectory))
                }
                trace?.mark("deleteShards.end")
                var writtenBytes = 0
                trace?.mark("writeShards.begin", metadata: ["count": String(dirtySessions.count)])
                for (path, value, operation) in dirtySessions {
                    let metadata = PersistentSessionMetadata(
                        version: Self.persistentCacheVersion,
                        path: path,
                        size: value.key.size,
                        modifiedAt: value.key.modifiedAt,
                        lastOffset: value.lastOffset,
                        endedWithNewline: value.endedWithNewline,
                        previousTotalTokens: value.previousTotalTokens,
                        canIncrementFromOffset: value.canIncrementFromOffset,
                        forkReplayActive: value.forkReplayActive,
                        lastSkippedForkReplayTokenAt: value.lastSkippedForkReplayTokenAt?.timeIntervalSince1970,
                        recentUsageFingerprints: value.recentUsageFingerprints,
                        eventCount: value.events.count
                    )
                    writtenBytes += try Self.persist(
                        value,
                        metadata: metadata,
                        operation: operation,
                        cacheDirectory: cacheDirectory
                    )
                }
                trace?.mark("writeShards.end", metadata: ["bytes": String(writtenBytes)])
                if shouldFinalizeLegacyV8Migration {
                    trace?.mark("finalizeV8Migration.begin")
                    try Self.markLegacyV8MigrationComplete()
                    if let legacyDirectory = Self.legacyV8NamespaceDirectory {
                        try? FileManager.default.removeItem(at: legacyDirectory)
                    }
                    lock.lock()
                    self.shouldFinalizeLegacyV8Migration = false
                    lock.unlock()
                    trace?.mark("finalizeV8Migration.end")
                }
                if !dirtySessions.isEmpty, let legacyV5CacheURL = Self.legacyV5CacheURL {
                    try? FileManager.default.removeItem(at: legacyV5CacheURL)
                }
                trace?.end("ok", metadata: [
                    "dirtySessions": String(dirtySessions.count),
                    "deletedSessions": String(deletedPersistentPaths.count),
                    "writtenBytes": String(writtenBytes)
                ])
            } catch {
                if shouldFinalizeLegacyV8Migration {
                    lock.lock()
                    legacyV8MigrationFailed = true
                    lock.unlock()
                }
                trace?.end("failed", metadata: ["error": error.localizedDescription])
                // The in-memory cache is still valid; a disk-cache miss should never block the dashboard.
            }
        }

        private func loadPersistentCacheIfNeeded() {
            lock.lock()
            if didLoadPersistentCache {
                lock.unlock()
                return
            }
            lock.unlock()

            Self.removeLegacyCaches()
            guard !CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled else {
                lock.lock()
                didLoadPersistentCache = true
                lock.unlock()
                return
            }

            let trace = RefreshPerformanceProbe.begin("usageCache.loadPersistent")
            trace?.mark("loadV9.begin")
            let current = Self.loadV9SessionCache()
            trace?.mark("loadV9.end", metadata: ["sessions": String(current.count)])
            trace?.mark("loadV8Migration.begin")
            let migrationAlreadyComplete = Self.isLegacyV8MigrationComplete
            let legacy = migrationAlreadyComplete ? [:] : Self.loadLegacyV8SessionCache()
            trace?.mark("loadV8Migration.end", metadata: ["sessions": String(legacy.count)])

            var mergedCount = 0
            var migratedCount = 0
            lock.lock()
            if !didLoadPersistentCache {
                for (path, value) in current where storage[path] == nil {
                    storage[path] = value
                    mergedCount += 1
                }
                for (path, value) in legacy where storage[path] == nil {
                    storage[path] = value
                    pendingPersistence[path] = .replace
                    mergedCount += 1
                    migratedCount += 1
                }
                shouldFinalizeLegacyV8Migration = !migrationAlreadyComplete
                    && Self.legacyV8NamespaceDirectory.map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } == true
                didLoadPersistentCache = true
            }
            lock.unlock()
            trace?.end("ok", metadata: [
                "sessions": String(mergedCount),
                "migratedSessions": String(migratedCount),
                "namespace": Self.cacheNamespace
            ])
        }

        private static func loadV9SessionCache() -> [String: CachedSession] {
            guard let directory = sessionCacheDirectory,
                  let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return [:]
            }

            var loaded: [String: CachedSession] = [:]
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".meta.json") {
                guard let data = try? Data(contentsOf: url),
                      let metadata = try? JSONDecoder().decode(PersistentSessionMetadata.self, from: data),
                      metadata.version == persistentCacheVersion,
                      url.standardizedFileURL == sessionMetadataURL(for: metadata.path, in: directory).standardizedFileURL,
                      let persistentEvents = loadPersistentEvents(
                        from: sessionEventsURL(for: metadata.path, in: directory),
                        expectedCount: metadata.eventCount
                      ) else {
                    continue
                }
                let path = URL(fileURLWithPath: metadata.path).resolvingSymlinksInPath().path
                let key = SessionCacheKey(
                    path: path,
                    size: metadata.size,
                    modifiedAt: metadata.modifiedAt,
                    deviceID: nil,
                    inode: nil,
                    statusChangedSeconds: nil,
                    statusChangedNanoseconds: nil
                )
                loaded[path] = CachedSession(
                    key: key,
                    events: persistentEvents.map(tokenEvent),
                    lastOffset: metadata.lastOffset,
                    endedWithNewline: metadata.endedWithNewline,
                    previousTotalTokens: metadata.previousTotalTokens,
                    canIncrementFromOffset: metadata.canIncrementFromOffset,
                    forkReplayActive: metadata.forkReplayActive,
                    lastSkippedForkReplayTokenAt: metadata.lastSkippedForkReplayTokenAt.map(Date.init(timeIntervalSince1970:)),
                    recentUsageFingerprints: metadata.recentUsageFingerprints
                )
            }
            return loaded
        }

        private static func loadLegacyV8SessionCache() -> [String: CachedSession] {
            guard let directory = legacyV8SessionCacheDirectory,
                  let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return [:]
            }

            var loaded: [String: CachedSession] = [:]
            for case let url as URL in enumerator where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let file = try? JSONDecoder().decode(LegacyPersistentSessionFile.self, from: data),
                      file.version == legacyPersistentCacheVersion else {
                    continue
                }
                let entry = file.entry
                let path = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path
                let key = SessionCacheKey(
                    path: path,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt,
                    deviceID: nil,
                    inode: nil,
                    statusChangedSeconds: nil,
                    statusChangedNanoseconds: nil
                )
                loaded[path] = CachedSession(
                    key: key,
                    events: entry.events.map(tokenEvent),
                    lastOffset: entry.lastOffset,
                    endedWithNewline: entry.endedWithNewline,
                    previousTotalTokens: entry.previousTotalTokens,
                    canIncrementFromOffset: entry.canIncrementFromOffset,
                    forkReplayActive: entry.forkReplayActive,
                    lastSkippedForkReplayTokenAt: entry.lastSkippedForkReplayTokenAt.map(Date.init(timeIntervalSince1970:)),
                    recentUsageFingerprints: entry.recentUsageFingerprints
                )
            }
            return loaded
        }

        private static func keysMatch(_ lhs: SessionCacheKey, _ rhs: SessionCacheKey) -> Bool {
            lhs.path == rhs.path
                && lhs.size == rhs.size
                && abs(lhs.modifiedAt - rhs.modifiedAt) < 0.001
        }

        private static var legacyV5CacheURL: URL? {
            cacheRootURL?
                .appendingPathComponent("CodexTokenBar", isDirectory: true)
                .appendingPathComponent("session-token-events-v5.json")
        }

        private static var sessionCacheDirectory: URL? {
            cacheRootURL?
                .appendingPathComponent(appCacheDirectoryName, isDirectory: true)
                .appendingPathComponent(cacheNamespace, isDirectory: true)
                .appendingPathComponent("session-token-events-v9", isDirectory: true)
        }

        private static var legacyV8SessionCacheDirectory: URL? {
            legacyV8NamespaceDirectory?
                .appendingPathComponent("session-token-events-v6", isDirectory: true)
        }

        private static var cacheNamespaceDirectory: URL? {
            cacheRootURL?
                .appendingPathComponent(appCacheDirectoryName, isDirectory: true)
                .appendingPathComponent(cacheNamespace, isDirectory: true)
        }

        static var legacyV8NamespaceDirectory: URL? {
            cacheRootURL?
                .appendingPathComponent(appCacheDirectoryName, isDirectory: true)
                .appendingPathComponent(previousCacheNamespace, isDirectory: true)
        }

        private static var legacyV8MigrationMarkerURL: URL? {
            cacheNamespaceDirectory?.appendingPathComponent(legacyMigrationMarkerName)
        }

        static var isLegacyV8MigrationComplete: Bool {
            guard let marker = legacyV8MigrationMarkerURL else { return false }
            return FileManager.default.fileExists(atPath: marker.path)
        }

        private static var snapshotCacheURL: URL? {
            cacheRootURL?
                .appendingPathComponent(appCacheDirectoryName, isDirectory: true)
                .appendingPathComponent(cacheNamespace, isDirectory: true)
                .appendingPathComponent("session-token-snapshots-v9.json")
        }

        private static var legacyCacheURLs: [URL] {
            guard let cacheRootURL else { return [] }
            let oldSharedFiles = [2, 3, 4, 5].map { version in
                cacheRootURL
                    .appendingPathComponent("CodexTokenBar", isDirectory: true)
                    .appendingPathComponent("session-token-events-v\(version).json")
            }
            let oldSharedDirectories = [
                cacheRootURL
                    .appendingPathComponent("CodexTokenBar", isDirectory: true)
                    .appendingPathComponent("session-token-events-v6", isDirectory: true),
                cacheRootURL
                    .appendingPathComponent("CodexTokenBar", isDirectory: true)
                    .appendingPathComponent("session-token-snapshots-v6.json")
            ]
            return oldSharedFiles + oldSharedDirectories
        }

        private static var cacheRootURL: URL? {
            if let override = ProcessInfo.processInfo.environment[cacheDirectoryEnvironmentKey],
               !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            }
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        }

        private static func removeLegacyCaches() {
            for url in legacyCacheURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        private static func markLegacyV8MigrationComplete() throws {
            guard let marker = legacyV8MigrationMarkerURL else {
                throw CocoaError(.fileNoSuchFile)
            }
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("v8-to-v9\n".utf8).write(to: marker, options: [.atomic])
        }

        private static func sessionMetadataURL(for path: String, in directory: URL) -> URL {
            directory.appendingPathComponent("\(digest(path) ?? "empty").meta.json")
        }

        private static func sessionEventsURL(for path: String, in directory: URL) -> URL {
            directory.appendingPathComponent("\(digest(path) ?? "empty").events.jsonl")
        }

        private static func persist(
            _ session: CachedSession,
            metadata: PersistentSessionMetadata,
            operation: PersistenceOperation,
            cacheDirectory: URL
        ) throws -> Int {
            let metadataURL = sessionMetadataURL(for: metadata.path, in: cacheDirectory)
            let eventsURL = sessionEventsURL(for: metadata.path, in: cacheDirectory)
            var writtenBytes = 0

            switch operation {
            case .replace:
                let eventData = try encodeEventLines(session.events)
                try eventData.write(to: eventsURL, options: [.atomic])
                writtenBytes += eventData.count
            case .append(let fromEventIndex):
                let canAppend = persistedEventCount(at: metadataURL) == fromEventIndex
                    && FileManager.default.fileExists(atPath: eventsURL.path)
                if canAppend {
                    let eventData = try encodeEventLines(session.events.suffix(from: fromEventIndex))
                    if !eventData.isEmpty {
                        let handle = try FileHandle(forWritingTo: eventsURL)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: eventData)
                        writtenBytes += eventData.count
                    }
                } else {
                    let eventData = try encodeEventLines(session.events)
                    try eventData.write(to: eventsURL, options: [.atomic])
                    writtenBytes += eventData.count
                }
            }

            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: metadataURL, options: [.atomic])
            writtenBytes += metadataData.count
            return writtenBytes
        }

        private static func persistedEventCount(at metadataURL: URL) -> Int? {
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(PersistentSessionMetadata.self, from: data),
                  metadata.version == persistentCacheVersion else {
                return nil
            }
            return metadata.eventCount
        }

        private static func encodeEventLines<S: Sequence>(_ events: S) throws -> Data where S.Element == TokenEvent {
            let encoder = JSONEncoder()
            var data = Data()
            for event in events {
                data.append(try encoder.encode(persistentEvent(event)))
                data.append(0x0A)
            }
            return data
        }

        private static func loadPersistentEvents(from url: URL, expectedCount: Int) -> [PersistentEvent]? {
            guard expectedCount >= 0,
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            let decoder = JSONDecoder()
            var events: [PersistentEvent] = []
            events.reserveCapacity(expectedCount)
            for line in data.split(separator: 0x0A) {
                let event: PersistentEvent? = autoreleasepool {
                    try? decoder.decode(PersistentEvent.self, from: Data(line))
                }
                guard let event else {
                    return nil
                }
                events.append(event)
            }
            guard events.count == expectedCount else { return nil }
            return events
        }

        private static func persistentEvent(_ event: TokenEvent) -> PersistentEvent {
            PersistentEvent(
                timestamp: event.timestamp.timeIntervalSince1970,
                sessionID: event.sessionID,
                model: event.model,
                tokens: event.tokens,
                inputTokens: event.inputTokens,
                cachedInputTokens: event.cachedInputTokens,
                outputTokens: event.outputTokens,
                reasoningOutputTokens: event.reasoningOutputTokens,
                // Keep the established non-content fields even after live
                // excerpts are stripped, so old cache diagnostics retain a
                // stable schema without retaining conversation text.
                userPromptDigest: Self.redactedConversationDigest(for: event.userPrompt),
                assistantResponseDigest: Self.redactedConversationDigest(for: event.assistantResponse)
            )
        }

        private static func redactedConversationDigest(for value: String) -> String? {
            value.isEmpty ? "redacted" : Self.digest(value)
        }

        private static func tokenEvent(_ event: PersistentEvent) -> TokenEvent {
            TokenEvent(
                timestamp: Date(timeIntervalSince1970: event.timestamp),
                sessionID: event.sessionID,
                model: event.model,
                tokens: event.tokens,
                inputTokens: event.inputTokens,
                cachedInputTokens: event.cachedInputTokens,
                outputTokens: event.outputTokens,
                reasoningOutputTokens: event.reasoningOutputTokens,
                userPrompt: "",
                assistantResponse: ""
            )
        }

        private static func digest(_ value: String) -> String? {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }

            var hash: UInt64 = 0xcbf29ce484222325
            for byte in normalized.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            return String(format: "%016llx", hash)
        }

    }

    static let sessionEventCache = SessionEventCache()
    static var isPersistentSessionEventCacheDisabled: Bool {
        ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE"] == "1"
    }

    static var preciseSnapshotBuildCountForTesting: Int {
        sessionEventCache.snapshotBuildCountForTesting
    }

    static var fullSessionParseCountForTesting: Int {
        sessionEventCache.fullSessionParseCountForTesting
    }

    static var incrementalSessionParseCountForTesting: Int {
        sessionEventCache.incrementalSessionParseCountForTesting
    }

    static func resetPreciseSnapshotBuildCountForTesting() {
        sessionEventCache.resetSnapshotBuildCountForTesting()
    }

    static func clearUsageCachesForTesting() {
        sessionEventCache.clearForTesting()
        CodexUsageHistoryIndex.clearForTesting()
    }

    static func clearInMemoryUsageSnapshotsForTesting() {
        sessionEventCache.clearSnapshotsForTesting()
    }

    struct OfficialThreadSummary {
        let totalTokens: Int
        let peakThreadTokens: Int
        let totalThreads: Int
    }

    struct ThreadInfo {
        let title: String
        let updatedAt: Date?
    }

    struct ParsedTokenUsage {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        let totalTokens: Int
    }

    struct ParsedTokenUsageLine {
        let timestamp: Date
        let total: ParsedTokenUsage?
        let last: ParsedTokenUsage?
    }

    struct SessionParseResult {
        let events: [TokenEvent]
        let lastOffset: UInt64
        let endedWithNewline: Bool
        let previousTotalTokens: Int?
        let forkReplayActive: Bool
        let lastSkippedForkReplayTokenAt: Date?
        let recentUsageFingerprints: [UsageSnapshotFingerprint]
    }

    struct SessionLineStreamResult {
        let lastOffset: UInt64
        let resumeOffset: UInt64
        let endedWithNewline: Bool
        let contentHash: String
        let chunkHashes: [IndexedChunkHash]
        let validationChunkHash: IndexedChunkHash?
    }

    struct TokenCacheAccumulator {
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningOutputTokens = 0
        var totalTokens = 0
        var calls = 0

        mutating func add(_ event: TokenEvent) {
            inputTokens += event.inputTokens
            cachedInputTokens += min(event.cachedInputTokens, event.inputTokens)
            outputTokens += event.outputTokens
            reasoningOutputTokens += event.reasoningOutputTokens
            totalTokens += event.tokens
            calls += 1
        }

        var breakdown: TokenCacheBreakdown {
            TokenCacheBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: totalTokens,
                calls: calls
            )
        }
    }

}
