import Foundation

extension CodexUsageAnalyzer {
    struct SessionCacheKey: Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    final class SessionEventCache: @unchecked Sendable {
        private static let persistentCacheVersion = 5
        private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"

        private struct PersistentCache: Codable {
            let version: Int
            let entries: [PersistentEntry]
        }

        private struct PersistentEntry: Codable {
            let path: String
            let size: UInt64
            let modifiedAt: TimeInterval
            let events: [PersistentEvent]
        }

        private struct PersistentEvent: Codable {
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

        private let lock = NSLock()
        private var storage: [String: (key: SessionCacheKey, events: [TokenEvent])] = [:]
        private var didLoadPersistentCache = false
        private var isDirty = false

        func events(for path: String, key: SessionCacheKey) -> [TokenEvent]? {
            loadPersistentCacheIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            guard storage[path]?.key == key else { return nil }
            return storage[path]?.events
        }

        func store(_ events: [TokenEvent], for path: String, key: SessionCacheKey) {
            loadPersistentCacheIfNeeded()
            lock.lock()
            storage[path] = (key, events)
            isDirty = true
            lock.unlock()
        }

        func flushPersistentCache() {
            lock.lock()
            if CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled {
                isDirty = false
                lock.unlock()
                return
            }
            guard isDirty else {
                lock.unlock()
                return
            }
            let entries = storage.map { path, value in
                PersistentEntry(
                    path: path,
                    size: value.key.size,
                    modifiedAt: value.key.modifiedAt,
                    events: value.events.map { event in
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
                )
            }
            isDirty = false
            lock.unlock()

            guard let cacheURL = Self.cacheURL else { return }
            do {
                Self.removeLegacyCaches()
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let cache = PersistentCache(version: Self.persistentCacheVersion, entries: entries)
                let data = try JSONEncoder().encode(cache)
                try data.write(to: cacheURL, options: [.atomic])
            } catch {
                // The in-memory cache is still valid; a disk-cache miss should never block the dashboard.
            }
        }

        private func loadPersistentCacheIfNeeded() {
            lock.lock()
            if didLoadPersistentCache {
                lock.unlock()
                return
            }
            defer {
                didLoadPersistentCache = true
                lock.unlock()
            }

            Self.removeLegacyCaches()
            guard !CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled else {
                return
            }

            guard let cacheURL = Self.cacheURL,
                  let data = try? Data(contentsOf: cacheURL),
                  let cache = try? JSONDecoder().decode(PersistentCache.self, from: data),
                  cache.version == Self.persistentCacheVersion else {
                return
            }

            var loaded: [String: (key: SessionCacheKey, events: [TokenEvent])] = [:]
            for entry in cache.entries {
                let key = SessionCacheKey(path: entry.path, size: entry.size, modifiedAt: entry.modifiedAt)
                loaded[entry.path] = (
                    key,
                    entry.events.map { event in
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
                )
            }

            for (path, value) in loaded where storage[path] == nil {
                storage[path] = value
            }
        }

        private static var cacheURL: URL? {
            cacheRootURL?
                .appendingPathComponent("CodexTokenBar", isDirectory: true)
                .appendingPathComponent("session-token-events-v5.json")
        }

        private static var legacyCacheURLs: [URL] {
            guard let cacheRootURL else { return [] }
            return [2, 3, 4].map { version in
                cacheRootURL
                    .appendingPathComponent("CodexTokenBar", isDirectory: true)
                    .appendingPathComponent("session-token-events-v\(version).json")
            }
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
