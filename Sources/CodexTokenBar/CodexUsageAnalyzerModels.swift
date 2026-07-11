import Foundation

extension CodexUsageAnalyzer {
    struct SessionCacheKey: Codable, Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    struct SessionTreeSignature: Codable, Equatable {
        let localDate: String
        let utcOffsetSeconds: Int
        let files: [SessionCacheKey]
        let stateDatabase: SessionCacheKey?
    }

    final class SessionEventCache: @unchecked Sendable {
        private static let persistentCacheVersion = 8
        private static let appCacheDirectoryName = "CodexTokenBarSwift"
        static let cacheNamespace = "swift-usage-cache-2026-07-v3"
        private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"

        private struct PersistentSessionFile: Codable {
            let version: Int
            let entry: PersistentEntry
        }

        private struct PersistentEntry: Codable {
            let path: String
            let size: UInt64
            let modifiedAt: TimeInterval
            let lastOffset: UInt64
            let endedWithNewline: Bool
            let previousTotalTokens: Int?
            let canIncrementFromOffset: Bool
            let forkReplayActive: Bool
            let lastSkippedForkReplayTokenAt: TimeInterval?
            let events: [PersistentEvent]
        }

        struct PersistentEvent: Codable {
            let timestamp: TimeInterval
            let sessionID: String
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
            init(
                key: SessionCacheKey,
                events: [TokenEvent],
                lastOffset: UInt64,
                endedWithNewline: Bool,
                previousTotalTokens: Int?,
                canIncrementFromOffset: Bool,
                forkReplayActive: Bool,
                lastSkippedForkReplayTokenAt: Date?,
                migratedFromLegacyCache _: Bool = false
            ) {
                self.key = key
                self.events = events
                self.lastOffset = lastOffset
                self.endedWithNewline = endedWithNewline
                self.previousTotalTokens = previousTotalTokens
                self.canIncrementFromOffset = canIncrementFromOffset
                self.forkReplayActive = forkReplayActive
                self.lastSkippedForkReplayTokenAt = lastSkippedForkReplayTokenAt
            }
        }

        private let lock = NSLock()
        private var storage: [String: CachedSession] = [:]
        private var snapshotStorage: [String: (signature: SessionTreeSignature, snapshot: DashboardSnapshot)] = [:]
        private var snapshotBuildCount = 0
        private var fullSessionParseCount = 0
        private var incrementalSessionParseCount = 0
        private var didLoadPersistentCache = false
        private var dirtyPaths = Set<String>()
        private var deletedPersistentPaths = Set<String>()
        private var isSnapshotDirty = false

        func cachedSession(for path: String, key: SessionCacheKey) -> CachedSession? {
            loadPersistentCacheIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            guard let cached = storage[path], Self.keysMatch(cached.key, key) else {
                return nil
            }
            return cached
        }

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

        func store(_ session: CachedSession, for path: String) {
            loadPersistentCacheIfNeeded()
            lock.lock()
            storage[path] = session
            dirtyPaths.insert(path)
            deletedPersistentPaths.remove(path)
            lock.unlock()
        }

        func retainOnly(paths: Set<String>) {
            loadPersistentCacheIfNeeded()
            lock.lock()
            let removed = Set(storage.keys).subtracting(paths)
            for path in removed {
                storage.removeValue(forKey: path)
                deletedPersistentPaths.insert(path)
                dirtyPaths.remove(path)
            }
            lock.unlock()
        }

        func snapshot(for root: String, signature: SessionTreeSignature) -> DashboardSnapshot? {
            loadPersistentCacheIfNeeded()
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
            dirtyPaths.removeAll()
            deletedPersistentPaths.removeAll()
            isSnapshotDirty = false
            lock.unlock()
        }

        func flushPersistentCache() {
            let trace = RefreshPerformanceProbe.begin("usageCache.flushPersistent")
            lock.lock()
            if CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled {
                dirtyPaths.removeAll()
                deletedPersistentPaths.removeAll()
                isSnapshotDirty = false
                lock.unlock()
                trace?.end("disabled")
                return
            }
            let dirtyPaths = dirtyPaths
            let deletedPersistentPaths = deletedPersistentPaths
            let dirtySessions = dirtyPaths.compactMap { path in storage[path].map { (path, $0) } }
            let shouldRemovePersistentSnapshot = isSnapshotDirty
            guard !dirtySessions.isEmpty || !deletedPersistentPaths.isEmpty || shouldRemovePersistentSnapshot else {
                lock.unlock()
                trace?.end("clean")
                return
            }
            self.dirtyPaths.removeAll()
            self.deletedPersistentPaths.removeAll()
            isSnapshotDirty = false
            lock.unlock()

            guard let cacheDirectory = Self.sessionCacheDirectory else {
                trace?.end("no-cache-directory")
                return
            }
            do {
                trace?.mark("removeLegacy.begin")
                Self.removeLegacyCaches()
                trace?.mark("removeLegacy.end")
                if let snapshotURL = Self.snapshotCacheURL {
                    trace?.mark("removePersistentSnapshot.begin")
                    try? FileManager.default.removeItem(at: snapshotURL)
                    trace?.mark("removePersistentSnapshot.end")
                }
                guard !dirtySessions.isEmpty || !deletedPersistentPaths.isEmpty else {
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
                    try? FileManager.default.removeItem(at: Self.sessionEntryURL(for: path, in: cacheDirectory))
                }
                trace?.mark("deleteShards.end")
                var writtenBytes = 0
                trace?.mark("writeShards.begin", metadata: ["count": String(dirtySessions.count)])
                for (path, value) in dirtySessions {
                    let entry = PersistentEntry(
                        path: path,
                        size: value.key.size,
                        modifiedAt: value.key.modifiedAt,
                        lastOffset: value.lastOffset,
                        endedWithNewline: value.endedWithNewline,
                        previousTotalTokens: value.previousTotalTokens,
                        canIncrementFromOffset: value.canIncrementFromOffset,
                        forkReplayActive: value.forkReplayActive,
                        lastSkippedForkReplayTokenAt: value.lastSkippedForkReplayTokenAt?.timeIntervalSince1970,
                        events: value.events.map(Self.persistentEvent)
                    )
                    let file = PersistentSessionFile(version: Self.persistentCacheVersion, entry: entry)
                    let data = try JSONEncoder().encode(file)
                    writtenBytes += data.count
                    try data.write(to: Self.sessionEntryURL(for: path, in: cacheDirectory), options: [.atomic])
                }
                trace?.mark("writeShards.end", metadata: ["bytes": String(writtenBytes)])
                if !dirtySessions.isEmpty, let legacyV5CacheURL = Self.legacyV5CacheURL {
                    try? FileManager.default.removeItem(at: legacyV5CacheURL)
                }
                trace?.end("ok", metadata: [
                    "dirtySessions": String(dirtySessions.count),
                    "deletedSessions": String(deletedPersistentPaths.count),
                    "writtenBytes": String(writtenBytes)
                ])
            } catch {
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
            trace?.mark("loadV6.begin")
            let loaded = Self.loadV6SessionCache()
            trace?.mark("loadV6.end", metadata: ["sessions": String(loaded.count)])

            var mergedCount = 0
            lock.lock()
            if !didLoadPersistentCache {
                for (path, value) in loaded where storage[path] == nil {
                    storage[path] = value
                    mergedCount += 1
                }
                didLoadPersistentCache = true
            }
            lock.unlock()
            trace?.end("ok", metadata: [
                "sessions": String(mergedCount),
                "namespace": Self.cacheNamespace
            ])
        }

        private static func loadV6SessionCache() -> [String: CachedSession] {
            guard let directory = sessionCacheDirectory,
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
                      let file = try? JSONDecoder().decode(PersistentSessionFile.self, from: data),
                      file.version == persistentCacheVersion else {
                    continue
                }
                let entry = file.entry
                let path = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path
                let key = SessionCacheKey(path: path, size: entry.size, modifiedAt: entry.modifiedAt)
                loaded[path] = CachedSession(
                    key: key,
                    events: entry.events.map(tokenEvent),
                    lastOffset: entry.lastOffset,
                    endedWithNewline: entry.endedWithNewline,
                    previousTotalTokens: entry.previousTotalTokens,
                    canIncrementFromOffset: entry.canIncrementFromOffset,
                    forkReplayActive: entry.forkReplayActive,
                    lastSkippedForkReplayTokenAt: entry.lastSkippedForkReplayTokenAt.map(Date.init(timeIntervalSince1970:))
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
                .appendingPathComponent("session-token-events-v6", isDirectory: true)
        }

        private static var snapshotCacheURL: URL? {
            cacheRootURL?
                .appendingPathComponent(appCacheDirectoryName, isDirectory: true)
                .appendingPathComponent(cacheNamespace, isDirectory: true)
                .appendingPathComponent("session-token-snapshots-v6.json")
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

        private static func sessionEntryURL(for path: String, in directory: URL) -> URL {
            directory.appendingPathComponent("\(digest(path) ?? "empty").json")
        }

        private static func persistentEvent(_ event: TokenEvent) -> PersistentEvent {
            PersistentEvent(
                timestamp: event.timestamp.timeIntervalSince1970,
                sessionID: event.sessionID,
                tokens: event.tokens,
                inputTokens: event.inputTokens,
                cachedInputTokens: event.cachedInputTokens,
                outputTokens: event.outputTokens,
                reasoningOutputTokens: event.reasoningOutputTokens,
                userPromptDigest: Self.digest(event.userPrompt),
                assistantResponseDigest: Self.digest(event.assistantResponse)
            )
        }

        private static func tokenEvent(_ event: PersistentEvent) -> TokenEvent {
            TokenEvent(
                timestamp: Date(timeIntervalSince1970: event.timestamp),
                sessionID: event.sessionID,
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
    }

    struct SessionLineStreamResult {
        let lastOffset: UInt64
        let endedWithNewline: Bool
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
